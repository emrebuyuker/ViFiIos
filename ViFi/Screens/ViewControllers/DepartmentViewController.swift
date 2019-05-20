//
//  DepartmentViewController.swift
//  ViFi
//
//  Created by Emre BÜYÜKER on 15.05.2019.
//  Copyright © 2019 Emre BÜYÜKER. All rights reserved.
//

import UIKit
import Firebase
import FirebaseDatabase

class DepartmentViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    var uniName = String()
    var facName = String()
    var departmentsNameArray = [String]()
    
    @IBOutlet weak var departmentTableView: UITableView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.departmentTableView.delegate = self
        self.departmentTableView.dataSource = self
        
        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
        facName = tabBar.facNameVariable
    }
    
    override func viewWillAppear(_ animated: Bool) {
        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
        facName = tabBar.facNameVariable
        
        departmentsNameArray.removeAll()
        
        getDataFromFireBase()
    }
    
    func getDataFromFireBase() {
        let dataBaseRefence = Database.database().reference()
        
        dataBaseRefence.child("Universities").child(uniName).child(facName).observe(DataEventType.childAdded) { (snapshot) in
            if (snapshot.key != "fakname" ) {
                self.departmentsNameArray.append(snapshot.key)
            }
            self.departmentTableView.reloadData()
        }
    }
    
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.departmentsNameArray.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = departmentTableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath) as! DepartmentTableViewCell
        cell.departmentNameLabel.text = departmentsNameArray[indexPath.row]
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let depName = departmentsNameArray[indexPath.row]
        let tabBar = tabBarController as! BaseTabbarVC
        tabBar.depNameVariable = depName
        self.tabBarController?.selectedIndex = 3
    }
}

//
//  LessonViewController.swift
//  ViFi
//
//  Created by Emre BÜYÜKER on 16.05.2019.
//  Copyright © 2019 Emre BÜYÜKER. All rights reserved.
//

import UIKit
import Firebase
import FirebaseDatabase

class LessonViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    
    var uniName = String()
    var facName = String()
    var depName = String()
    var lessonsNameArray = [String]()
    
    @IBOutlet weak var lessonTableView: UITableView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.lessonTableView.delegate = self
        self.lessonTableView.dataSource = self
        
        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
        facName = tabBar.facNameVariable
        depName = tabBar.depNameVariable
        
        getDataFromFireBase()

    }
    
    override func viewWillAppear(_ animated: Bool) {
        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
        facName = tabBar.facNameVariable
        depName = tabBar.depNameVariable
    }
    
    func getDataFromFireBase() {
        let dataBaseRefence = Database.database().reference()
        
        dataBaseRefence.child("Universities").child(uniName).child(facName).child(depName).observe(DataEventType.childAdded) { (snapshot) in
            if (snapshot.key != "bolname" ) {
                self.lessonsNameArray.append(snapshot.key)
            }
            print(self.lessonsNameArray)
            self.lessonTableView.reloadData()
        }
    }
    
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.lessonsNameArray.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = lessonTableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath) as! LessonTableViewCell
        cell.lessonNameLabel.text = lessonsNameArray[indexPath.row]
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let depName = lessonsNameArray[indexPath.row]
        let tabBar = tabBarController as! BaseTabbarVC
        tabBar.depNameVariable = depName
        //self.tabBarController?.selectedIndex = 3
    }
}
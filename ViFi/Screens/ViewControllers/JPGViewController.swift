//
//  JPGViewController.swift
//  ViFi
//
//  Created by Emre BÜYÜKER on 16.05.2019.
//  Copyright © 2019 Emre BÜYÜKER. All rights reserved.
//

import UIKit
import Firebase
import FirebaseDatabase
import SDWebImage

class JPGViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    var uniName = String()
    var facName = String()
    var depName = String()
    var lessonName = String()
    var examName = String()
    var examType = String()
    var imageURLArray = [String]()
    var imageURL = String()
    var info = 0
    
    @IBOutlet weak var JPGTableView: UITableView!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.title = examName
        
        self.JPGTableView.delegate = self
        self.JPGTableView.dataSource = self
        self.JPGTableView.rowHeight = self.JPGTableView.bounds.height
        
        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
        facName = tabBar.facNameVariable
        depName = tabBar.depNameVariable
        
        tabBar.tabBar.isUserInteractionEnabled = false
        
        getDataFromFireBase()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
        facName = tabBar.facNameVariable
        depName = tabBar.depNameVariable
        
        tabBar.tabbarItem.isUserInteractionEnabled = false
    }
    
    func getDataFromFireBase() {
        let dataBaseRefence = Database.database().reference()
        dataBaseRefence.child("Universities").child(uniName).child(facName).child(depName).child(lessonName).child(examName).observe(DataEventType.childAdded) { (snapshot) in
            
            for child in snapshot.children {
                if let childSnapshot = child as? DataSnapshot,
                    let value = childSnapshot.childSnapshot(forPath: "downloadURL").value as? String {
                    self.imageURLArray.append(value)
                }
            }
            self.JPGTableView.reloadData()
        }
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.imageURLArray.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = JPGTableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath) as! JPGTableViewCell
        cell.imegeView?.sd_setImage(with: URL(string: imageURLArray[indexPath.item]), placeholderImage: nil)
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        imageURL = imageURLArray[indexPath.item]
        performSegue(withIdentifier: "toZoomView", sender: nil)
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "toZoomView" {
            let destinationVC = segue.destination as! JPGZoomViewController
            destinationVC.imageURL = self.imageURL
        }
    }
}
